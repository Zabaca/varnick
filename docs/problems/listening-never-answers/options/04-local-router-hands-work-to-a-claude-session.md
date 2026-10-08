---
problem: listening-never-answers
title: Option 01 plus a hand-off, where a request for work becomes a prompt for a new Claude session
summary: Option 01's deciding step gains a fifth answer, `claude`, for requests to get something done rather than found ("ask Claude to fix the deploy in launchy"). Launchy puts the request into the panel's prompt line, with `#project` when one was named, as if typed. It says it is ready, and the session starts only when the user presses ↩. Finding stays local, as in option 01. Only what the user said goes to Claude, and only on ↩, as a typed prompt does today.
status: proposed
---

## Solution

This builds on option 01 and changes only its first step and what follows it for one answer.

The deciding call can now answer `claude` when the request asks for work rather than for something already seen: "ask Claude to …", "start a session to …", "have Claude look at …". It also returns the project's name when the request names one, and the message, with the "ask Claude to" part removed.

For `claude`, Launchy:

1. brings the panel forward on search and gives it focus, which option 01, speaking only, never does;
2. types `#project` (when there is one) and the message into the field, so the panel is in its ordinary prompt mode. The project word resolves, or doesn't, as the user's own typing would, and matching sessions list under the prompt line;
3. says "Ready to start a Claude session in <project>. Press return.", or "… Press return." with no project.

↩ starts the session as any prompt does. ↓ then ↩ opens a listed session instead, and the user can edit the message first. Nothing starts by voice alone.

Every other request is answered locally, exactly as in option 01.

## Trade-offs

- **"Ask it to do something" covers work too,** not only finding. It doesn't send History, Bookmarks or sessions anywhere to get there: Claude gets the message only when the user presses ↩, which is what typing it would do.
- **One key press stands between a misheard request and a running session.** A find misread as `claude` leaves an unwanted prompt in the field, which Esc clears. A request for work misread as a find gets a search; saying it again with "ask Claude" fixes it.
- **Dictated prompts are rough.** The transcriber is built for conversation, and file names, flags and code words come out wrong. The prompt is on screen to fix before ↩, but a long technical request is still better typed.
- **The deciding step has more to tell apart,** five answers instead of four, on a small model. The `--ask` tuning set grows to include work requests.
- **The voice starts sessions only on this Mac, or on a peer named in the request.** Peers (`^name`) are left out at first: see Out of Scope.

## User Stories

1. As a Launchy user, I want to say "Hey Launchy, ask Claude to fix the failing build in launchy" and find the prompt ready in the panel, in that project, so that one key starts it.
2. As a Launchy user, I want to see and edit the dictated prompt before anything starts, so that a misheard word doesn't become Claude's task.
3. As a Launchy user, I want the sessions that match the prompt listed under it, as when I type, so that I can carry on an existing one instead.
4. As a Launchy user, I want finding things to stay as in option 01, private and spoken.
5. As a Launchy user, I want nothing about my history or sessions sent to Claude to get a session started, only what I said.

## Implementation Decisions

**Everything not below** is as in option 01.

**Deciding**
- The decide prompt's JSON gains:
  - `claude` as a value of `source`;
  - for it, a `project` field (a name or empty) and a `message` field (the request without "ask Claude to" and the like).
- `query` stays for the finding sources.
- A `claude` reply with an empty message falls back to the whole request as the message.

**The prompt line**
- `#` and the project's name, with spaces removed, are typed before the message, then the message. Launchy doesn't resolve the project itself: the prompt line's matching does, as for typed text. If nothing matches, the word stays in the message for the user to see.
- The message is cut to the length the prompt line already accepts. The sessions listed under it follow the existing rules: the session queries and the chosen embedder only, never a reranker or a log.
- No `^peer` or `@agent` words are added by voice.

**Speaking**
- One fixed sentence names the project as it resolved, or none. It is not a Text generation reply, so there is no second call for `claude`.
- Written to the transcript as a `[launchy]` line, as option 01's answers are.

**Command line**
- `--ask` prints the `claude` answer's project and message.

## Testing Decisions

- The decide step's reader gains `claude` with its project and message: the same pure seam as option 01.
- **By hand, after a restart:**
  - "Hey Launchy, ask Claude to" plus a small task in a project you have. The prompt line shows `#project` resolved and the message, sessions list under it, nothing starts until ↩, and ↩ starts it in that project.
  - The same without a project. The prompt starts in the default folder on ↩.
  - A find request still answers as in option 01.
  - Esc on a ready prompt clears it and starts nothing.

## Out of Scope

- Starting on a peer or as an agent by voice.
- Sending the request straight to a running session's pane.
- Starting a session without ↩.
- Claude reading History, Bookmarks or sessions (option 03).

## Further Notes

- Accept together with option 01, or after it. It can't stand alone.
- It is the one case where a spoken request brings the panel forward. The user chose speech only for option 01 (2026-10-08), so this needs their say-so on that point too.
- **Verified in the code:**
  - typed text without a leading `?` or `!` is a prompt;
  - `#word` resolves among projects as it is typed;
  - matching sessions list under the prompt line;
  - ↩ starts the session, and ↓ then ↩ opens a listed one.
- No new ADR beyond option 01's. Its text would add that a spoken request can fill the prompt line and never starts a session by itself.
