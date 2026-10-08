---
problem: session-turns-not-visible
title: A board in the panel, with turns reported by hooks
summary: The board replaces the panel's content the way Settings does, toggled by ⌘⇧B, `!kanban` or `!tabs`. Claude reports each turn's start and end through hooks Launchy adds beside its SessionStart hook, as one word in a file in the pane's folder. The app reads that file for this Mac's panes, started or not, and the relay reads it for a paired Mac, which sends it in its `sessions` and `status` replies (protocol 12). A session waiting on the user in mid-turn is in Stopped with a mark saying why: a permission dialog, a question from Claude, a plan to approve or an MCP server's request. Done closes the pane the way ⌘W does and keeps the session in a Completed list in the saved state.
status: accepted
---

## Solution

Claude Code reports turns through its hooks. Every Claude pane is already started with a SessionStart hook passed in `--settings` (ADR 0001). The same settings gain hooks that write one word to a file in the pane's folder: **working** when the user submits a prompt, **waiting** when Claude ends its turn, when a turn fails on an API error, after `/clear` or `/resume`, and when Claude has sat idle at its prompt; **permission** when a permission dialog appears, and working again once the tools Claude asked for have run. Launchy writes the first word itself as it starts claude. The file is on the session's host, whoever is in control and whether or not any client is attached. So this Mac reads it for its own panes, including tabs not opened since a restart, and a paired Mac's relay reads it from disk and sends it with the sessions it lists.

The board is a view of the panel, like Settings: it replaces whatever the panel shows, and closing it goes back to the tab or search underneath. It has three columns. **Running** and **Stopped** hold one card per Claude pane on this Mac and one per session open on a paired Mac, by turn. A session waiting on a permission dialog is in Stopped with a "Needs permission" mark that sets it apart from a finished turn. One waiting on a question from Claude, a plan to approve or an MCP server's request has a mark of its own. **Completed** holds the sessions the user marked done. ↩ or a double-click opens a card. Dragging a card onto Completed, D, or the End session shortcut (⌘W) marks it done: its pane closes as ⌘W closes it, and the session is kept in a Completed list in `sessions.json`. Opening a completed card resumes it in a new tab, which takes it out of Completed.

## Trade-offs

- **The board is right for every session it shows,** started or not, on any host, whether a client is attached here or not. That covers the cases that matter most: background tabs after a restart, and sessions on other Macs.
- **Hooks are Claude Code's documented interface,** and the mechanism is the one ADR 0001 already uses. The title glyph (option 02) is an undocumented detail of how Claude Code draws.
- **The relay reads the turn with Launchy not running,** as it reads the conversation today. The phone page (`sessions-out-of-reach-from-the-phone`, option 01, user story 3: "see whether Claude is waiting on me") and the agent panes of `orchestration-lives-in-one-session` option 04 can read the same file.
- **It changes the claude command line** on every host, the Ryzen included, and **the peer protocol** (version 12). Both Macs have to be built from the same commit, and the Ryzen's relay reinstalled. A Mac left on the old build stops talking to the others until it is rebuilt.
- **Shell counts need the Stop hook's second entry,** which changes the claude command line again (amendment of 2026-10-07). A host not rebuilt, or the Ryzen's relay not reinstalled, starts sessions without it, and those show a turn that left only shells, agents or teammates as Stopped (amended 2026-10-08, at the user's request: agents and teammates come from the same file). A session already running shows them only after it is started again.
- **Sessions already running don't have the new hooks.** With Keep sessions running on (it is, here) they survive the restart that installs this build, and keep their old settings until they are next started. Until then their turn isn't known (open question 2).
- **Esc in mid-turn and a plain Deny fire no hook at all** (live test on the Studio, 2.1.291: no `Stop`, no tool hooks, and no `idle_prompt`, which comes 60 s after a normal turn end but is skipped when an interaction is newer than the turn's end). The reader corrects them from the transcript (Reading the turn, below), at the cost of reading a transcript's tail when it changed after the turn file.
- **One case shows Stopped while Claude still works:** a Stop hook of the user's own that sends Claude back to work (no prompt is submitted, so nothing writes working). Background agents, workflows and shells Claude left running after its turn ended show as Running (Background work).
- **A permission dialog shows at once,** as Stopped with "Needs permission", and stays marked while it waits.
- **After Allow, the mark stays until the allowed tool has finished.** Nothing in Claude Code fires between the answer and the tool's end, so a long command, once allowed, shows "Needs permission" until it is done.
- **Sessions started with permission prompts on run one more short shell per batch of tool calls.** Sessions started with Skip permissions, Launchy's default, run none. A session started with Skip permissions that shows a dialog anyway keeps the mark until its next prompt, turn end or idle notification.
- **Questions, plan approvals and MCP requests are marked in every session, at no cost on other tool calls.** Their hooks match those tools or events by name. After esc on a question or a rejected plan, the mark stays as a denial's does.
- **Every prompt runs one more short shell command and every turn end two** (the second saves `Stop`'s input, Background work), beside the user's own hooks on the same events.
- **The board has the panel's fixed size** (decided), 760 points wide, so each column is about 245 points and long titles are cut. Option 03 was the resizable alternative.
- **⌘W on the board ends the selected session.** Pressed out of habit, it marks a Stopped card done in one press and closes its pane. The session stays resumable from Completed and Recent, and a Running card asks first.

## User Stories

1. As the user, I want one view of every Claude session open on this Mac and my paired Macs, so that I don't cycle through tabs and Macs to find one.
2. As the user, I want to see which sessions Claude is working on and which are waiting on me, so that I answer the waiting ones first.
3. As the user, I want the board right after a Launchy restart, for tabs I haven't opened since, so that a session waiting in a background tab isn't missed.
4. As the user, I want each card to show its Mac, project and agent as the session list's pills, so that I can tell where a session runs and what it is.
5. As the user, I want to open a card and land in its pane with focus, so that I can answer it straight away.
6. As the user, I want opening a paired Mac's session from the board to show its card with Take over, so that opening it never takes it from the Mac typing into it.
7. As the user, I want to mark a session done, which closes its pane, so that finished work leaves my tabs.
8. As the user, I want done sessions kept in Completed across restarts, so that I can see what's finished and go back to one.
9. As the user, I want opening a completed card to resume it in a new tab and take it out of Completed, so that the board shows it's live again.
10. As the user, I want to mark a paired Mac's session done even when this Mac can't close it, so that it leaves my Running and Stopped columns.
11. As the user, I want one shortcut to show the board and the same one to go back where I was, so that the board is a glance, not a detour.
12. As the user, I want `!kanban` and `!tabs` to open the board, so that I can reach it from the search field.
13. As the user, I want to move between cards, open one, mark one done and close the board from the keyboard, so that I don't need the mouse.
14. As the user, I want a turn I interrupted not to show as working for long, so that the board stays trustworthy.
15. As the user, I want closing a pane from the board to follow the same rules as ⌘W, so that the board can't end a session ⌘W wouldn't.
16. As the user, I want a session waiting on a permission dialog in Stopped, marked as needing permission, and one waiting on a question, a plan or an MCP server's request marked for that, so that I can tell it from a finished turn and know what it needs.
17. As the user, I want a session I've answered to go back to Running, so that the board stops showing it as waiting on me.

## Implementation Decisions

**Turn state**
- A turn is **working**, **waiting**, or **permission** (waiting on a permission dialog), **question**, **plan** or **input** (below), and **background**, which the reader derives (Background work, below). Running shows working and background. Stopped shows the rest, each but waiting with its mark. The columns are labelled as the user named them. In code and docs "a session runs" already means its zmx session is alive (`status.running`), so the turn uses its own words.
- The hooks, beside the existing SessionStart one and like it added to the user's own hooks: `UserPromptSubmit` writes working; `Stop`, `StopFailure`, `Notification` of type `idle_prompt`, and `SessionStart` for the `clear` and `resume` sources write waiting, except that `clear` writes working when the file says plan (below). The permission hooks are below (Permission dialogs).
- `SessionStart` is limited to those two sources, each its own entry with an exact matcher: per Claude Code's docs it also fires after a compaction (`compact`), which can come in the middle of a turn, and at `startup`, which Launchy's own first word covers (below).
- The turn file holds the word and nothing else, never the hook's JSON (`Stop`'s input is saved whole in a file of its own, for background shells, which Background work explains): `UserPromptSubmit`'s input carries the prompt, which must not be copied anywhere new.
- Every hook prints nothing. In 2.1.291's help text, `UserPromptSubmit`'s output is shown to Claude, and `PermissionRequest`'s is read as a decision to allow or deny. A `PermissionRequest` hook that exits 0 with no output leaves the decision to the user, and an `Elicitation` hook the answer.
- It is a dot file beside the SessionStart hook's file in the pane's folder. The hook finds it from the session file's own path, so the environment claude is given, on a Mac and on the headless host, doesn't change. The pane folder already exists before claude starts (the SessionStart hook needs it).
- A pane that starts claude writes the first word itself, at the point where it clears the session file: working when it passes a first message, waiting otherwise (no message, or `--resume`). So a session started again isn't read as its last run's turn, and a first turn shows as working whether or not `UserPromptSubmit` runs for a message given on the command line (unverified). The headless host's start does the same at the same point. A pane that attaches to a session already running starts no claude and leaves the file alone.
- No file means the turn isn't known, which after this build only a session started before it has. Its card goes in Stopped, marked "Turn not known" (decided, open question 2).
- A hook writes its word only when the file holds a different one, so the file's date is when the current state began. That date is what a card's "Working 12m" or "Waiting 4m" counts from. Without this, the batch hook would rewrite working after every batch and reset it. The exception is `UserPromptSubmit`, which always writes working, so a prompt after Esc or a Deny (whose file still says working or permission) starts a fresh working age.
- One reader of the file lives in LaunchyPeer beside the session file's, used by the app and by both kinds of relay. It builds on Linux.
- **Reading the turn: the transcript correction.** When the file says anything but waiting (Esc on a question leaves question) and the conversation's transcript (its path is the `transcript_path` in the pane's session file) changed after the turn file, the reader reads the transcript's tail. It goes by the last user or assistant entry, skipping local-command and `!` bash entries and sidechain entries. If that entry is Claude Code's interrupt marker ("[Request interrupted by user…") or a tool result that denies the tool, the turn reads as waiting, dated by that entry. A marker isn't trusted when a user entry with a later timestamp exists, which agent teams' write order can produce. The reader never rewrites the file, and only the word and its age leave the host. The exact markers come from a builder's check of real transcripts.

**Permission dialogs** (decided by the user on 2026-10-06: Stopped, with a mark)
- **Marking it.** `PermissionRequest` ("When a permission dialog is displayed") writes permission. Its matcher excludes the two tools that have marks of their own (Questions, plans and MCP input, below), so each dialog runs exactly one of Launchy's `PermissionRequest` entries.
- **No notification marker.** 2.1.291 sends a dialog's notification 6 s after the dialog appears if it is still open, in the terminal and in the SDK's path alike, and never once it is answered. But the notification carries a message and a type, not the tool's name. A dialog kind that names no type is sent as `permission_prompt`; the plan approval names none, and a question's arrives as `permission_prompt` too (live test). So a `permission_prompt` hook would overwrite a question's or plan's mark after 6 s. `PermissionRequest` already runs for every dialog in the ask path, so it is the only marker.
- **No overwriting.** Nothing else overwrites the mark while the dialog waits: the idle notification isn't sent while a turn runs or a dialog is open.
- **Back to working after Allow.** `PostToolBatch` writes working. 2.1.291 runs it "once after every tool call in a batch has resolved, before the next model request", so it covers tools that failed as well as those that ran. That is one shell per batch, rather than one per tool for the `PostToolUse` and `PostToolUseFailure` pair.
- **Only in sessions that can show a dialog.** The batch hook goes in the settings only when Launchy starts claude without `--dangerously-skip-permissions`: the session's own setting, else this Mac's Skip permissions, or the headless host's. The settings are built with the rest of the command line in the one place both hosts share. Changing the setting applies to sessions started after.
- **Where the batch hook isn't registered,** the mark clears on the next hook that fires anyway: the next prompt (working), the turn's end or failure (waiting), the idle notification (waiting), or another dialog (permission). That covers a session started with Skip permissions that shows a dialog all the same, for instance if the user leaves bypass mode inside it (untested).
- **After Deny,** 2.1.291 tells Claude "STOP what you are doing and wait for the user to tell you how to proceed" and records "[Request interrupted by user for tool use]": the turn ends as an interrupt. No hook fires after it (live test), so the transcript correction makes it plain waiting.
- **Deny with feedback** ("tell Claude what to do differently") hands Claude the user's words ("To tell you how to proceed, the user said: …") without telling it to stop, so the turn goes on. That is inferred from the message, not tested. The batch hook then returns the card to Running.
- **Untested, for the check by hand:**
  - whether a subagent's dialogs run `PermissionRequest`;
  - whether a session started with Skip permissions can show a dialog for an ordinary tool (a question always can, below).
- **Claude Code versions across hosts.**
  - The Studio, the Air and the Ryzen all ran 2.1.291, npm's `latest`, on 2026-10-06 (the coordinator's check). npm's `stable` is 2.1.285.
  - Updates still arrive with `autoUpdates` off: the Ryzen moved from 2.1.285 to 2.1.291. The risk is drift, a host falling behind or one on `stable`.
  - 2.1.291's settings reader drops a hook event it doesn't know with a note ("Unknown hook event … was ignored") and keeps the rest, checked in the binary. So a newer event in the settings costs an older host only that event's mark, as long as the older version also ignores it rather than rejecting the settings. If it rejected them, the SessionStart hook Launchy depends on would go too.
  - Whether 2.1.285 ignores an unknown event is untested. Check it once by hand: start claude 2.1.285 with these settings and see that the SessionStart hook's file appears.
  - If it rejects them, register only the events the host's claude knows, read from its version.
- **Verified against the 2.1.291 binary:** the event names, their help text, the notification types, the 6 s and 60 s timings, the idle notification's conditions, and what a denial tells Claude. A live test on the Studio (2026-10-06, 2.1.291) passed every flow here except Esc and a plain Deny, which the transcript correction covers.

**Questions, plans and MCP input** (decided by the user on 2026-10-06: a mark of its own for each, open question 9)
- **What waits.** Claude asking a question (`AskUserQuestion`), a plan waiting for approval (`ExitPlanMode`), and an MCP server asking for input (elicitation) all wait on the user in mid-turn.
- **Why `PermissionRequest`.** 2.1.291 returns "ask" for a tool that requires the user's interaction before it looks at bypass mode, and `AskUserQuestion` requires it. So a question goes through the permission flow, and through `PermissionRequest` hooks, even with Skip permissions; its dialog is drawn by `AskUserQuestionPermissionDialog`. The plan approval is a permission dialog too (`permission_exit_plan_mode_v2`). Without a split, both would show as "Needs permission".
- **Marking.** `PermissionRequest` entries with exact matchers: `AskUserQuestion` writes question, `ExitPlanMode` writes plan. 2.1.291's matching:
  - a matcher made only of letters, digits, `_` and `|` is a list of exact names;
  - any other matcher is a JavaScript regular expression, tested against the tool's name and its legacy aliases. Neither tool has an alias in 2.1.291.

  The permission entry's matcher is a regular expression that matches every name but those two, so each dialog runs one entry.
- **Not `PreToolUse`.** It does fire before the dialog: 2.1.291 applies a `PreToolUse` decision before the permission prompt. But it fires before the permission check, so the catch-all permission entry would then overwrite its word. It also fires when a hook of the user's or a plugin's answers the question and no dialog shows. `PermissionRequest` is the dialog itself.
- **Back to working.** `PostToolUse` with the exact matcher `AskUserQuestion|ExitPlanMode` writes working. The answers reach the tool through the permission result (a hook can answer a question the same way, through `updatedInput`), so the tool runs, and `PostToolUse` follows, as soon as the user answers. An exact matcher runs only for those two tools, so no other tool call pays for it, and the entry is in every session's settings, Skip permissions or not.
- **Answers that still count.** Choosing "respond to Claude" instead of an option, and 2.1.291 answering a question by itself after the user goes idle (`afk_auto_advance`), both end with the tool running, so `PostToolUse` returns the card to Running (inferred).
- **Esc on a question.** The question's reject resolves the request as deny (`tengu_ask_user_question_rejected`), which ends the turn as a Deny does. No hook follows, so the transcript correction makes it plain waiting. That esc goes to that reject is inferred.
- **A rejected plan.** Feedback sends Claude back to planning in the same turn (inferred, from "User feedback on this plan"). No `PostToolUse` follows a denied tool, so the mark stays while Claude replans. Then the next `ExitPlanMode` marks the new plan, or the turn's end writes waiting. In a session started with permission prompts on, the batch hook clears it sooner.
- **Approving a plan with "Yes, clear context and …"** (offered with `showClearContextOnPlanAccept`) resolves `ExitPlanMode` as a deny in 2.1.291 (found by the reviewer), clears the conversation and queues the plan as a message that continues on its own, so no `PostToolUse` follows. `SessionStart` for `clear` therefore writes working when the file says plan; a `/clear` typed at the prompt comes after the turn's end, when the file says waiting. The live test confirmed it: `UserPromptSubmit` doesn't fire there, and `SessionStart` (`clear`) alone gives working.
- **MCP input.** `Elicitation` ("When an MCP server requests user input") writes input. `ElicitationResult` ("After a user responds to an MCP elicitation"), whatever the answer, writes working, since the MCP tool call and the turn go on. Both match every server.
- **Notification types.** None of these has a type of its own except MCP input (`elicitation_dialog`, `elicitation_url_dialog`); 2.1.291 has no type for a question or a plan (above). Notifications aren't used.
- **Verified against the 2.1.291 binary:**
  - that a question asks before bypass mode is considered;
  - the dialog components' names;
  - the matcher rules and the absence of aliases;
  - the order of `PreToolUse` against the prompt;
  - the reject handler's deny;
  - the AFK auto-answer;
  - the elicitation events' help text;
  - the default notification type, and the plan's notification text.
- **Untested:** every flow end to end. The plan dialog running `PermissionRequest` and the esc mapping are inferred.

**Background work** (added on 2026-10-06 at the user's request; the note's wording is a recommendation. **Amended on 2026-10-07 at the user's request: background shells count too**, as agents do. **Amended on 2026-10-08 at the user's request: agents move to the Stop input, and teammates count while busy**)
- **What.** A turn that ended with background agents, workflows or shells still running is Running, not Stopped. Claude isn't waiting on the user: Claude Code says "Waiting for 1 background agent to finish", and each one that ends starts a new turn by itself, a shell's end included.
- **The note.** "1 background agent", "2 background agents", "1 background shell", "1 background workflow", using Claude Code's own words, rather than "1 agent in background". Several kinds read "1 background agent, 2 teammates, 1 workflow, 2 shells", in that order (teammates added 2026-10-08). The time counts from the turn's end.
- **A shell counts like an agent** (decided by the user on 2026-10-07; this replaces the 2026-10-06 rule that a turn leaving only shells stays Stopped). That includes a server that never ends: 18 of the 241 shells here never reported an end. Its card stays Running until the user drags it to Completed or stops the shell. Claude Code's own waiting line doesn't count shells, which is why the signal differs from the agents' (below). A Monitor counts as a shell: Claude Code lists it as one (verified live, 2.1.292).
- **The signal for workflows: the transcript** (verified in the binary and in 14 days of transcripts here; agents used it until 2026-10-08, below). Shells, agents and teammates have their own (Shells, and Agents and teammates, below).
  - At each turn's end Claude Code writes a `system` entry, subtype `turn_duration`, carrying `pendingBackgroundAgentCount` and `pendingWorkflowCount` when either is above 0. These are the numbers behind its line (233 and 60 such entries here).
  - Each agent or workflow that ends writes a task-notification user entry (`origin.kind` `task-notification`, with a status of completed, failed, killed or stopped). A completed one starts a turn that writes a lower count; a stop starts none.
  - So the count is the last `turn_duration`'s, minus the agent and workflow notifications after it, floored at 0.
  - Those notifications are the summaries `Dynamic workflow …` and `Background workflow …` for workflows; the reader now counts only these. The agents' (`Agent "…"`, `Background agent "…" was stopped by the user`, `N background agents were stopped by the user`) were read for the agent count until 2026-10-08, when agents moved to the Stop input (below); the stop forms are plain text with no `<summary>`, so the `N` form never matched.
  - Over 223 transcripts with a turn end, every finished session comes to 0; the only two above 0 were live sessions with an agent running.
  - The summaries are Claude Code's English text and can change in a release, as the interrupt marker can.
- **Shells: the `Stop` hook's input** (added 2026-10-07; verified live on 2.1.292 with Launchy's own settings, and in the binary).
  - A shell has no count in `turn_duration`. But `Stop`'s input carries `background_tasks`, the session's tasks still running, each `{id, type, status, description, …}`. A background shell is `"type":"shell","status":"running"` with its `command`; one that had ended by the turn's end is absent, and an agent or workflow is `subagent` or `workflow`. A Monitor is listed as `shell` too.
  - So the Stop hook gains a second entry that saves its stdin, unparsed, to `.launchy-stop` beside the turn file, by rename, whatever the turn. `StopFailure`, which ends a turn on an API error with no task list in its input, gains an entry that only dates the existing file again, so shells still running from the turn before aren't dropped (a shell started in the failed turn isn't known). A shell that ended in a later turn is dropped by its notification, which for an end in mid-turn is an `attachment` entry (below); one that ended in a turn longer than the 64 KB tail can still slip through and show as running. The touch can also come after `ClaudeSession.checkTurn` has read the new turn file, and nothing reads again unless the transcript changes, so the card then shows Stopped until it does (a false Stopped, not a false Running). A hook's shell can't parse JSON without jq, and the Swift reader can. The file holds the same as the transcript does (Claude's last reply and the shells' commands) and never the prompt, which `Stop`'s input doesn't carry.
  - The reader takes the ids of the `shell` tasks with status `running`, and counts those with no ended notification for the same `<task-id>` in the transcript's tail. Ended means a notification with a status of completed, failed, killed or stopped, read as the workflows' are: `Background command "…" completed (exit code 0)`, `… failed with exit code N`, `Background command "…" was stopped` (a kill from `/tasks`, which starts no turn, as an agent's does not; two seen here), and a Monitor's `Monitor "…" stream ended`. A `Monitor event` has no status and ends nothing. An end that comes in the middle of a turn isn't a user entry but an `attachment` entry (`attachment.type` `queued_command`, `attachment.commandMode` `task-notification`, the same text in its `prompt`; 704 across the transcripts here, 117 of them with the user entries' `"kind":"task-notification"`), so both are read. Only a user entry starts a turn, so only it counts workflows. Matching by id needs no turn-end date for a shell, which never runs again, and counts it once; a subagent's end is dated (Agents come from the Stop input, below).
  - The file counts only if it isn't older than the turn's date by more than the same few seconds as a `turn_duration` (the two Stop entries run together), and only if its `session_id` is the pane's transcript's name. A turn that ended without `Stop` or `StopFailure` (Esc, a Deny, a restart) has an older file, so the old shells are dropped: a shell left running by an interrupted turn shows Stopped. After `/clear` or `/resume` the transcript is another conversation's, so the file is ignored whatever its age.
- **Agents come from the Stop input, and teammates count while busy** (amended 2026-10-08, at the user's request; this replaces "Agents and workflows stay on `turn_duration`", which kept the file for shells only). Workflows stay on `turn_duration`. The figures below were measured on the user's machine and are kept locally.
  - **Why.** Once a session spawns a named agent, Claude Code (2.1.295) stops writing `turn_duration`: a turn end has one before a session's first named spawn, and mostly not after. The transcript's agent count is then 0 for the rest of the session, and a lead with agents running showed Stopped. `background_tasks` doesn't depend on it. Keeping `turn_duration` for agents too would count a subagent twice, so agents leave it entirely.
  - **Subagents.** A `subagent` task with status `running` counts, unless a notification for its id (`<task-id>`, which is the task's `id`) says it ended after the Stop input was saved. The date is the stop file's own, not the turn file's: with Skip permissions on, a turn that a notification or a teammate starts writes no new word, so the turn file keeps the older date. An end before the input was saved doesn't count: a message to an agent that finished runs it again under the same id. A shell keeps the rule above, any end in the tail, since a shell never runs again and `StopFailure` re-dates the file after a shell that ended in the failed turn.
  - **Stops by the user.** Claude Code words one as plain text with the agent's description, not its id: `Background agent "…" was stopped by the user.`, or `N background agents were stopped by the user: "…", "…".` (read in the 2.1.295 binary, and the single and the bulk form in transcripts, as a user entry with `origin.kind` `task-notification` or a `queued_command` attachment). The description is the task's own, which Claude Code cut at 50 characters and "..." if it made it from the prompt (read in the binary), so it matches whole. A stop after the input was saved removes the subagent or teammate tasks with that description, but only if no more are running than the stop names: with two running under one description and one stopped, none is removed, and the card shows Running. This replaces the count of `N background agents` the `turn_duration` count was lowered by, which could not match, since the text has no `<summary>`.
  - **Teammates.** An agent started with a name is a `teammate` task with the same fields. An idle teammate stays `running` until its team shuts down, so status alone would pin a card to Running. The idle signal is in the lead's transcript. A teammate that goes idle sends the lead an `idle_notification` (a user entry whose text holds `<teammate-message teammate_id="…">` and a JSON body with `from` the name, `timestamp` and `idleReason`, `available` in every one seen); the lead's `SendMessage` to that name (a ` [ref]` after it is dropped), or its spawn, makes it busy again. The notification arrives in the transcript when the lead next reads its mailbox, which can be many minutes after it was sent, so it is dated by its own `timestamp`, not the entry's. A teammate is busy when its latest spawn or message to it is not older than its latest idle notification, so one that never sends idle is busy.
  - **Matching a task to a name.** The task has an id and a description but no name, and its id appears nowhere on disk. Its description is the `description` of the `Agent` call that spawned it, which also carries the `name` (checked on real teammates). The reader reads the whole transcript for these, since a spawn is far before a 64 KB tail. The app reads it once and then only what was added (one table per transcript in `TranscriptReader.busyTeammates`, up to 64 transcripts). A relay is a new process for each ask, so it reads a lead's transcript whole on every ask, about 140 ms for 48 MB; that is accepted, and no offsets are saved between asks. A teammate whose spawn isn't in the transcript, because it came from the conversation before a `/resume`, counts busy, and so do two running teammates with one description unless as many spawns carry it. Being shown Running by mistake is the cheap error; a Stopped card hides work.
  - **Not used.** `~/.claude/teams/<team>/config.json` lists a team's members by name but not their task ids or whether they are idle, and its inboxes are emptied once read. A `TeammateIdle` hook would need another change to the claude command line and gives no busy-again event. A raw agent id as a `SendMessage` target is not matched to a teammate's name.
  - **Known gaps.**
    - A session that has spawned a named agent counts no workflows, since they come from a `turn_duration` that is no longer written.
    - A teammate whose spawn is in an earlier conversation counts busy for as long as it runs, so a card whose only running teammates are such idle ones stays Running until the team shuts down.
    - A teammate messaged by another teammate, not the lead, shows idle until it reports.
    - A lead that has not yet read a teammate's idle notification shows that teammate busy, so the card stays Running until it does.
    - A subagent that ended in a turn that failed on an API error, after the input was saved by the turn before, shows Running until the next turn, since `StopFailure` re-dates the file.
- **Derived by the reader.** The workflows' count and the Stop input's tasks are read when the transcript or the turn file changed (`ClaudeSession.checkTurn`), and the Stop entries finish before the transcript gets its entries, so a turn end is read once both files are there.
  - When the corrected turn is waiting, `PaneFolder.corrected` takes the workflows' count from the same 64 KB tail it already reads, and the shells, agents and teammates from the stop file and that tail (busy teammates also from the whole transcript). Above 0 in any, it returns background, dated by the turn's end, with the counts.
  - A `turn_duration` counts only if it isn't older than that date by more than a few seconds (`Stop` writes the file just before the entry). So after a restart, whose first word comes later, an old count is ignored, and the old process's agents are orphaned anyway ("background agent(s) orphaned by previous process exit", verified).
- **Kills and exits.**
  - Stopping an agent or a shell from Claude Code (its stop-agents keys or `/tasks`) writes a notification: a shell's has its `<task-id>` and a status of stopped, and starts no turn; an agent's is plain text with its description (Stops by the user, above), and may start one. The reader subtracts them, and the card goes to Stopped with no prompt (seen for a shell in two transcripts, and for agents in the transcripts).
  - A session that exits closes its pane.
  - After `/clear` the new transcript has no turn end yet, so agents and shells still running from before show as plain Stopped. Whether either survives `/clear` is untested.
- **To peers: no protocol change.** The reader runs on the host for both relays, and the word `background` travels in the existing text field. An older build reads it as an unknown word, so its card says "Turn not known" until rebuilt. The count has no field, so a paired Mac's card says "Background work" without a number. A number would need a new field and a protocol bump.
- **Not used:**
  - `SubagentStart` and `SubagentStop` (`agent_id`): a count file needs read-modify-write across parallel hooks, and whether `SubagentStop` fires for an agent the user stops is unknown. No hook marks a background shell's start or end.
  - Counting background starts (`run_in_background` tool calls) against notifications: 33 of 269 starts here never got a notification.
  - A subagent transcript's date: an agent waiting on a long command writes nothing.

**Reading it on this Mac**
- Each Claude pane holds its turn. A pane on this Mac takes it from its file, read only when the file's date changed.
- While the board shows, it reads the file of every Claude pane here once a second, including panes not started since a restart, which have no half-second check of their own.
- When the board opens it asks zmx, once and off the main actor, which of the panes not started still have a running session. One whose session is gone (a reboot, or Keep sessions running off) is waiting, with "Resumes when opened", whatever its file says: a session killed mid-turn leaves working behind.
- A pane on a peer takes its turn from the host's `status`, which this Mac already polls every 5 s while it has a pane on a peer.

**Peers (protocol 12)**
- `PeerSessionStatus` and `PeerOpenSession` gain an optional turn (working, waiting or permission), and how long ago it began in seconds by the host's clock (so the two Macs' clocks don't have to agree), filled from the file by the relay: on a Mac where it fills in the conversation for `status` and where it lists open sessions; on the headless host in its `follow` and `sessions` answers. Only for a session whose zmx session runs.
- The protocol goes to 12. The headless relay is reinstalled, and `swift build` of the package is run on the Ryzen (ADR 0009, where-it-breaks › Peers).
- While the board shows, each answered peer is asked for its open sessions when it opens and every 5 s after, through the existing open-sessions refresh and its minimum interval. Every ask goes through `PeerManager.send` off the main actor; a Mac that doesn't answer loses its rows, as in the session list.

**The board**
- A flag on the model, toggled like Settings, shows the board in place of the panel's content. Settings shows over it. While the board shows, the panel isn't showing a terminal: the size is fixed and the tab shortcuts don't act on the tab underneath.
- **The layout is the prototype's variant A,** chosen by the user on 2026-10-06. It is on branch `prototype/session-board` at 2a98f47, under `prototypes/session-board/`: variant A's cards are in `VariantA.tsx`, and the parts the variants share are in `ui.tsx` and `board.ts`. Build from it: three equal columns of cards, without the prototype's Done button (see Done, below).
- Size: fixed like Settings, the panel's 760 width and Settings' 600 height, with a branch of its own in `panelHeight` (decided, open question 1).
- A header like Settings': the title, key hints (Open ↩, Done with the End session shortcut's keys, Close esc) and the close button.
- Three columns, each headed with its label and count, scrolling on their own.
- Running and Stopped: this Mac's Claude panes in tab order (a tab split into two Claude panes gives two cards), then each paired Mac's open sessions in the order of the peer list, as the session list orders them. A session marked done is never in these two columns, even if it is still open on a paired Mac. The mark is on that session (its pane id), not the conversation: a conversation resumed on a paired Mac in a new session shows as live work again, as resuming one here takes it out of Completed.
- Completed: newest first.
- **A card holds the prototype's "Standard" density** (decided), with no line for the last prompt:
  - **Top row.** The session's title, as the session list shows it (a tab's own name when the pane is its only one), with no Done button (see Done, below).
  - **Pills.** The session list's pills: `^host`, `#project`, and `@agent` when there is one. The folder's name shows only when no `#project` pill says it.
  - **Turn and time.** The turn with how long it has lasted: "Working 12m", "Waiting 4m", or "1 background agent 3m", "1 background shell 3m" for a turn that ended with background work running (Background work, below). Otherwise "Turn not known" with when it was last used, "Resumes when opened", or on a Completed card "Done … ago". After it, the card's note when it has one: "Controlled on…", "Lost connection", or "Still open on <Mac>" for a session marked done that still runs there.
  - **Marks.** "Needs permission" in orange, the colour the `!listen` row uses for a state that needs attention, and "Question", "Plan to approve" or "MCP input" the same way (decided, open question 9).
  - **Stopped's header** counts the cards that need permission.
  - **A selected Completed card** says that ↩ resumes it in a new tab.
- **A paired Mac's badge is its short handle,** `^air` for the MacBook Air, with the Mac's full name in the badge's tooltip. That is the session list's rule: the word from `Peer.shortcutHandles`, unless another paired Mac answers to it too. It differs on purpose from search results, which show the full name (decided).
- A card is selected by its id: the pane's id, for a paired Mac's card the id its pane would get when opened (the pane id in its zmx session's name), or the completed record's id. So the highlight follows it when it changes column and into its pane when it opens, as the session list's highlight follows its row.

**Keys and commands**
- A new shortcut, "Show / hide session board", in the Tabs group, default ⌘⇧B, local to the panel like ⌘, (decided, open question 8), handled with the others. The user confirmed ⌘⇧B on 2026-10-06; its earlier use, opening a web pane, was removed in ea7920a (2026-10-01). It shows the board from search or a tab, and hides it from the board. From Settings it closes Settings and shows the board.
- esc cancels a pending confirm (below), and otherwise closes the board, as it closes Settings. Closing goes back to the tab underneath, focused, or to search with focus in the field.
- On the board: ←/→ change column, ↑/↓ change card, ↩ opens, and D or the End session shortcut (⌘W) marks the selected card done, as the prototype has it. D is the board's own key, like the split picker's tile letters, and is free because the board has no text field. ⌘W is whatever the End session shortcut is bound to. These go through the panel's key monitor as the split picker's keys do, only while the board shows and Settings isn't over it. Any other key the board doesn't act on is let through.
- **⌘W and the tab underneath.**
  - Today End session acts only while the panel shows a terminal, and Settings turns that off (checked in the code). The board turns it off the same way, so ⌘W can't reach the tab underneath through the shortcut handler.
  - The board takes the End session key first. With a card selected it marks that card done, so ⌘W never closes the hidden tab's focused pane.
  - With no card selected, it does nothing, and the key is still taken: it is never let through to the tab or its terminal.
- `!kanban` opens the board. `!tabs` is another name for the same command: it matches the same row rather than adding a second one (decided, open question 6). The command clears the search field, so closing the board lands on an empty search.

**Opening a card**
- A pane here: its tab, with focus on that pane.
- A paired Mac's open session: the pane on its card, as the session list opens it.
- A completed card: resumed as Recent resumes, here or on its Mac (a still-open one there opens on its card, as search does), and taken out of Completed.
- The board closes as the card opens.

**Done**
- Done on a pane here ends it the way ⌘W does, with ⌘W's rules: on a peer the host decides whether to end or release, a card on the host asks first, and a card on a peer ends nothing there.
- The pane goes into Completed when it actually closes, not when Done is pressed: closing can wait on zmx or on a question, and a question answered No leaves the card where it was.
- When closing needs the question on the host's card, the board gives way to that tab so the question can be seen.
- **Done is a drag onto Completed, D, or the End session key** ("Done ⌘W" in the header). The user decided this on 2026-10-06 after seeing the board, and removed the Done button on cards, which read as a status (open question 7). A drop onto Running or Stopped does nothing, and Completed cards can't be dragged.
- Done on a working card asks first, inside the card (decided, open question 4): "Claude is working: Done again to end it", with End it and Keep. Dropping it on Completed, or pressing D or ⌘W, shows the question instead of ending it. End it, or a second D or ⌘W, ends it. Keep or esc cancels. A paired Mac's card with no pane here never asks: Done only marks it, and nothing ends.
- Done on a paired Mac's open session that has no pane here only marks it. This Mac can't close a pane on another Mac: the host takes `end` only from the Mac in control, and closing the host's own pane would need a new request and new rules there.

**Saved state**
- `sessions.json` gains an optional list of completed records beside Recent, so older files load and a newer file loads in an older build. It holds the same records Recent does: the pane's record as it closed, or for a paired Mac's session, a record with its Mac, folder, agent, conversation and title.
- The list is newest first and capped at 20, as Recent is (decided, open question 5). On load it keeps a session of this Mac only if its transcript exists, as Recent does.
- A conversation open in a pane here is never in Completed. Opening it any way (the board, Recent, search, `/resume` in a pane) drops the mark when the state is next saved. Recent's rebuild drops open conversations the same way.
- A completed session is in Recent too, as every ended session is.
- Marks are this Mac's own. They go in no peer reply and aren't synced.

## Testing Decisions

- No test target yet. The pure parts are where tests would go once one exists: reading the turn file, sorting cards into columns (marks hiding open sessions, gone sessions counted as waiting), and pruning Completed.
- `make build`, and `swift build` of the package on the Ryzen.
- By hand, after the user restarts Launchy (a restart ends sessions not in zmx; leave it to the user) and reinstalls the Ryzen's relay:
  - A new session started with a message is Running through its first turn, and Stopped when the turn ends. A session started without one, or resumed, is Stopped until a prompt. Esc in mid-turn brings it back to Stopped once the transcript has its interrupt marker, with no prompt needed. `/clear` and `/resume` leave it in Stopped. A turn long enough to compact stays in Running.
  - After another restart, a background tab not opened yet shows its true turn. One whose zmx session is gone shows Stopped with "Resumes when opened".
  - A session started before this build shows as not known (open question 2).
  - With Skip permissions off: a tool that needs permission puts the card in Stopped with "Needs permission" at once, and it stays marked past a minute of waiting. Allow returns it to Running when the tool has finished. A plain Deny makes it plain Stopped through the transcript correction. Deny with feedback returns it to Running.
  - With Skip permissions on, the session's settings have no batch hook.
  - On the Ryzen, a session started with the new settings still writes the SessionStart hook's file, and its permission dialogs mark the card.
  - With Skip permissions on and off:
    - A question marks the card "Question", not "Needs permission", and answering returns it to Running at once.
    - Esc on a question leaves it in Stopped, unmarked, through the transcript correction.
    - In plan mode, a plan marks it "Plan to approve". Approving returns it to Running, and so does "Yes, clear context and …". Rejecting with feedback keeps the mark while Claude replans.
    - An MCP server's request marks it "MCP input" until it is answered.
    - No other tool call runs the question's or plan's hook.
  - Done closes the pane, the card is in Completed, and it is still there after a restart. Opening it resumes it in a new tab and it leaves Completed. Resuming it from Recent instead also takes it out.
  - A session on the Studio and one on the Ryzen show with their `^host` pill and follow their turns within about 5 s. Opening one shows its card with Take over. Done on one this Mac controls ends or releases it as ⌘W would. Done on one with no pane here only marks it.
  - A Mac left on protocol 11 shows the mismatch on its peer row and its sessions leave the board.
  - ⌘⇧B from search, from a tab and from the board. The panel's size is right in every view.
  - esc cancels a pending confirm, then closes the board.
  - ⌘W and D mark the selected card done; on a Running card the second press ends it.
  - Dragging a Stopped card onto Completed marks it done. A dragged Running card shows the question. A drop on Running or Stopped does nothing, and a Completed card doesn't drag.
  - With no card selected, ⌘W does nothing, and the hidden tab's pane is never closed.
  - With Settings over the board, neither D nor ⌘W acts on a card.
  - A card's "Working" time keeps counting through tool calls, and resets when the turn changes or a new prompt is sent. Whether a prompt queued in mid-turn fires `UserPromptSubmit`, and so resets the age in mid-turn, is unverified.
  - A paired Mac's badge is `^air`, with the full name in its tooltip.
  - Background work:
    - A turn that ends with a background agent running shows Running with "1 background agent". When the agent ends, its new turn reads working, then the card goes to Stopped.
    - Two agents read "2 background agents", then "1" after one ends.
    - Stopping one from Claude Code moves the card to Stopped with no prompt.
    - A turn that ends with a background shell running (a Bash call with `run_in_background`) shows Running with "1 background shell", and so does a dev server that never ends: it stays Running until dragged to Completed. When the shell ends, its new turn reads working, then the card goes to Stopped. A shell stopped from `/tasks` moves the card to Stopped with no prompt.
    - An agent and a shell together read "1 background agent, 1 shell"; two shells read "2 background shells".
    - A session with a named teammate working shows Running with "1 background teammate" (or "1 background agent, 1 teammate" beside a subagent); once the teammate reports idle the card goes to Stopped, and a message to it brings it back to Running. A named subagent that was messaged after it finished counts again.
    - A permission dialog or a question in mid-turn, with a shell running from an earlier turn, keeps the card in Stopped with its mark.
    - Esc on a turn that left a shell running shows Stopped (no `Stop` hook fired).
    - A turn that fails on an API error after a shell was left running keeps "1 background shell" (`StopFailure` re-dates the file); `/resume` and `/clear` show no shells from the conversation before.
    - A session started before this build, or by a host not rebuilt, shows a shell alone as Stopped.
    - A Monitor reads as a shell.
    - A dynamic workflow reads "1 background workflow".
    - A session resumed after its claude exited shows no old count.
    - A Studio session with an agent running shows Running with "Background work" on the Air.

## Out of Scope

- Turn state anywhere but the board: a dot on tabs or session rows, notifications. The turn on each pane makes them easy later.
- Telling a shell that never ends (a dev server) from one that does: the card stays Running until the user drags it to Completed (Background work).
- Other dialogs that wait on the user in mid-turn, such as a proposed session goal or a paused session's choice. 2.1.291 has more of them than the four marked here.
- Closing a pane on another Mac, and syncing done marks between Macs.
- Dragging a card onto Running or Stopped, and dragging a Completed card (open question 7).
- A status menu item for the board, and a global shortcut (decided against, open question 8).
- Reordering cards by hand.

## Further Notes

- **The layout was settled by looking:** the user chose variant A of the prototype on branch `prototype/session-board` (2a98f47, `prototypes/session-board/`). That decided the fixed size, the cards' density, the confirm inside the card and the short peer badge. Its Done button and its verdict against dragging were reversed by the user after seeing the built board (open question 7). Variants B (session-list rows) and C (two columns and a Completed rail with dragging) were not chosen. The prototype's turns, peer sessions and permission cases are made up.
- **Shipping in two steps** suits `/to-tickets`: this Mac first (the hooks, the board, Done and Completed, with no protocol change and paired Macs' sessions left off), then protocol 12 with the paired Macs' sessions and turns.
- **An ADR on accepting:** turn state comes from hooks into the pane folder, and peers read it through the relay. It extends ADR 0001.
- **Glossary** (for `/domain-modeling`): Board, Turn (working, waiting), Completed. "Kanban" is only the command's name.
- **Considered and not proposed:**
  - A separate window: there is no sibling for a second window, and it would need its own rules for focus, hiding and pinning beside the panel's.
  - Columns in place of the session list: the list gives way to results at the first keystroke, and its height is counted row by row.
- **Open questions,** all decided by the user (option accepted on 2026-10-06):
  1. Decided by the user on 2026-10-06: fixed 760 × 600, like Settings.
  2. Decided by the user on 2026-10-06: a card whose turn isn't known goes in Stopped, marked "Turn not known". No fallback to the title glyph.
  3. Decided by the user on 2026-10-06: a session waiting on a permission dialog is Stopped, marked "Needs permission" (Permission dialogs, above).
  4. Decided by the user on 2026-10-06: yes, with the confirm inside the card ("Claude is working: Done again to end it").
  5. Decided by the user on 2026-10-06: Completed keeps the newest 20.
  6. Decided by the user on 2026-10-06: `!kanban` and `!tabs` are two names for one board, shown as one row.
  7. Decided by the user on 2026-10-06, and changed the same day after seeing the board: no Done button, since it read as a status. Done is dragging a card onto Completed, D, or the End session key. Drops onto Running or Stopped do nothing, and Completed cards can't be dragged.
  8. Decided by the user on 2026-10-06: ⌘⇧B is local to the panel, like ⌘,, not a global hotkey.
  9. Decided by the user on 2026-10-06: separate marks, "Question", "Plan to approve" and "MCP input", in Stopped as "Needs permission" is.
