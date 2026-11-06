---
problem: sessions-cant-start-sessions-in-other-projects
title: Option 01, with the new session told which session opened it and how to reach it, apart from its prompt
summary: As option 01, but Varnick adds a short paragraph to the new session's system prompt, outside the prompt the caller wrote. It names the session that opened it by its session id (which never changes) and its `SendMessage` name at the open (read from Claude Code's file for the caller's own conversation, as option 01 reads the new one's) and its project, says it may send that session its result when it finishes or a question only that session can answer, and says what to do when the name has gone stale. The prompt goes to Claude as written. The opener and its name are saved with the pane and passed at every start of it, until the pane moves to another conversation.
status: shipped
---

## Solution

Everything in option 01 holds; the new session is also told who opened it.

**What it is told.** One short paragraph, added to the new session's system prompt with Claude Code's own flag for appending to it, never to the prompt:

> This session was opened by another Claude session in Home, with Varnick's `tab_open`. Its session id is 0f3c2a9e-1111-4222-8333-944455566677 and its name was home-7d when it opened you. You can reach it with SendMessage to its name. Send it your result when you finish, or a question when you need a decision it can make and the user hasn't. Its name changes when it restarts: if a send fails, run `claude agents --json`, find the entry whose sessionId is the one above, and send to that entry's name. If there is no such entry, that session isn't running: say so here in your own reply, and never send to a name the failure suggests instead. The user can see this tab and type into it. (Made-up values.)

- **The opener's session id and name** are read from Claude Code's per-session file for the caller's current conversation, as option 01 reads the new session's by its id. The id is the identity; the name is only where to send now. If there is none (Claude Code didn't register the caller, or the file can't be read), the paragraph names the opener's project and tab and leaves out the address, and the reply says so.
- **The lookup is Claude Code's own command.** `claude agents --json` is documented for scripting and lists every running session with its session id and current name, so the new session never reads Claude Code's files. No Varnick tool is added for it (the user's decision, 2026-11-06).
- **Saved with the pane, passed at every start.** The opener's name and project as they were at the open are one optional field of the new pane's record, and every start of that pane (the first, a Restart, a restore) passes the paragraph again, so a compaction doesn't drop it. Claude Code records the system prompt with the conversation at its first request and resends that record on every resume until a compaction (its help says so), so a later start's text matters only after one.
- **Dropped when the pane moves on.** When the pane's conversation changes (`/clear`, `/resume`), the field is cleared and the next start passes nothing: the conversation that follows was not opened by that session. The running process keeps the paragraph until then (a launch flag can't be taken back).
- **The prompt is unchanged**, as in option 01, so the first prompt line the board and search fall back to is the caller's.

**The reply** adds that the new session was told the caller's name, or that it wasn't and why.

## Trade-offs

- **The session can report on its own.** A reply to a message needs no telling (the receiver answers the message's `from`, as tested on 2026-11-06), but a session given its work in the prompt has no `from` to answer. Told, it can send its result when done, or ask, and a lead that passed the work in the prompt still hears back.
- **It spends the opener's turns.** Each message starts a turn in the opener; a helper that messages often interrupts it. The paragraph names two occasions only: the result, and a question the user hasn't answered.
- **The name goes stale on a restart; the id doesn't.** Tested 2026-11-06: a restart kept the session id and changed the derived name (home-b3 became home-c0) and the socket. A send to the old name fails at once and suggests other live names that merely look alike, so the paragraph says to look the id up again and never to take a suggestion. A session told only the id, with no way to look it up, could not send at all (`SendMessage` takes a name, not an id); told the id and the lookup, it reached the renamed opener. An ended opener can't be reached until it is resumed; the new session says so in its own pane.
- **It needs the caller's name from Claude Code's file,** so even with option 02 one read of that file stays.
- **What reaches Anthropic** grows by the opener's name and project, sent with the new session's system prompt.
- **One saved field and one more flag at start,** where option 01 has none.
- **Unverified:** that an appended system prompt is kept when the session runs as an agent (`--agent`), which brings its own instructions.

## User Stories

1. As a lead session, I want a session I opened with its work in the prompt to send me its result when it finishes, so that I don't have to message it first to give it an address.
2. As the user, I want the session to message its opener only with its result or a question I haven't answered, so that the lead isn't interrupted for nothing.
3. As the user, I want the caller's prompt to reach the new session as written, so that the tab's first prompt and its title read as the caller wrote them.
4. As the user, I want the note to stop applying once I `/clear` that tab and use it for something else, so that the new conversation doesn't report to a session that never asked for it.
5. As a session, I want the reply to say whether the new session was told my name, so that I know whether to send it the address myself.

## Implementation Decisions

- **The opener's name** comes from the same read as option 01's, by the caller's conversation id (its record's current conversation), off the main actor, inside the call's wait.
- **Saved state:** one optional field on the session record, the opener's session id, name and project at the open; cleared when the pane's conversation changes. Older files load; an older build ignores it and starts the pane without the paragraph.
- **The paragraph** is fixed text with the two values filled in, built where the claude command is built, and passed only for a pane whose record has the field.
- **The log** adds whether the opener was named; never the name.
- **Docs** as option 01; the guide says what the new session is told; the privacy doc's line on what a session sends gains the opener's name.

## Testing Decisions

- **Before building:** start `claude` by hand with an appended system prompt and an agent, and check that it follows both.
- **By hand after a restart,** as option 01, plus: a session opened with its work in the prompt sends its result to the opener when it finishes, unasked; the opener receives it; after a Restart of the new pane it still knows the opener; after `/clear` in it and a Restart, it no longer mentions the opener; with the opener's file missing (a caller from before the build), the reply says the new session wasn't told the name.

## Out of Scope

As option 01. Telling a session who opened it with `pane_open` (unchanged, the user's decision), or with a Task or an automation.

## Further Notes

- **Read on the user's Mac, 2026-11-06 (Claude Code 2.1.319):** the help for the system prompt record (kept per conversation, resent on resume until a compaction); the session file holds the session id and its name. Not tried with an agent.
- **Considered: a line at the end of the prompt.** Simpler (no flag, no saved field), visible to the user in the tab's first prompt, and gone after `/clear` by itself; but it changes the caller's words as Claude reads them, and the session takes it as part of its task. Kept here as the fallback if appending to the system prompt doesn't work with agents.
- **Combines with** option 01 (it is a change to it), and with options 02, 03 and 05.
