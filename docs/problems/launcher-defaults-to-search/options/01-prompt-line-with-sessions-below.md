---
problem: launcher-defaults-to-search
title: The prompt line by default, with matching sessions below it
summary: Typed text is a prompt. Today's ask row shows under the field with the highlight on it, so ↩ starts the session, here or on the `^host` Mac. Below it, up to 5 matching sessions are listed, this Mac's open ones first, and ↓ ↩ opens one. Resolved `^host`, `#project` and `@agent` words, in any order, filter that list; with no text after them it shows their sessions newest first, and ↩ still starts an empty session there. A leading `?` is today's search unchanged, `!` is today's commands, and an empty field is today's session list. `>` means nothing any more. Prompts never reach the relevance filter or a log.
status: accepted
---

## Solution

Accepted by the user on 2026-10-07, relayed by the coordinator, with the open questions decided as follows:
- `?` keeps its 3 sessions above the pages, exactly today's search.
- Resolved tokens filter the list. Tokens alone and ↩ start an empty session there.
- The list holds sessions only, up to 5.
- A space and ↩ start an empty session in the default folder.
- A `^host` with no project filters the list to that Mac's sessions. With no `^host`, the list shows every Mac's.

Typing starts a session. What is typed shows on the **prompt line** under the field. This is today's ask row: the Claude tile, "Ask Claude Code", the `^host`, `#project` and `@agent` badges, and the message as it will be sent. The highlight starts on the prompt line, so ↩ starts the session, on this Mac or on the named one.

Below the prompt line, under a "Sessions" label, up to 5 sessions that match the message are listed, this Mac's open ones first. They are matched by keyword and by meaning, as the Sessions section of search matches them today. ↓ moves into the list and ↩ opens the highlighted session as a session result opens today. That means switching to its pane, opening it on its Mac's card, or resuming it. Typing moves the highlight back to the prompt line.

Resolved tokens filter the list. `#leeandco` keeps that project's sessions, `^air` keeps the Air's, and `@agent` keeps that agent's. The words can come in any order, so `#leeandco ^air fix the deploy` starts on the Air in its leeandco project. With tokens and no message, the list holds their sessions, newest first. ↩ on the prompt line still starts an empty session there, as `>#leeandco` and ↩ does today.

A leading `?` is today's search, unchanged. A leading `!` is today's commands. An empty field shows today's session list, and ↩ opens the highlighted row as it does now. `>` is no longer a prefix: typed at the start, it is part of the message like any other character.

## Trade-offs

- **↩ on typed text starts a session.** That costs a Claude process, a tab and a transcript, which then shows in Recent and search. Today a stray ↩ opens a page. Several things keep this deliberate:
  - The prompt line is on screen and highlighted, with its Start hint.
  - The highlight leaves it only when the user presses ↓.
  - Matches that arrive later never move the highlight.
  - A session started by mistake closes with ⌘W.
- **Search habits break.** A site name and ↩ now starts a session; it needs `?` first. A `>` typed from habit goes into the message. `>#leeandco fix` starts in the default folder with `>#leeandco` in the message, because tokens are read only at the start. The cue is the prompt line, which shows no project badge.
- **A message that starts with `?` or `!` needs a leading space.**
- **Prompts never reach the relevance filter.** Nothing typed goes to TypeSafe or the local reranker unless it starts with `?`. Today any query of 3 characters or more does, after a pause, including a prompt typed without `>`.
- **The embedder now reads prompts.** Each pause in typing embeds the message on this Mac to match sessions by meaning, as a search query is embedded today. The embedding stays on this Mac. A long pasted message is cut first (decisions below).
- **The panel's height follows the number of matches,** from 0 to 5, as the suggestions do under `>` today. Keyword matches show at once and meaning matches after the pause, so one keystroke can resize the panel twice.
- **Search is one keystroke further away.** `?` gives today's search exactly, including its 3 session rows above the pages.
- **More `?` searches may start cold.** The local reranker loads on first use and unloads after 10 idle minutes (verified). With fewer searches, more of them will wait for that load (inferred).

## User Stories

1. As a Launchy user, I want to type a message and press ↩ to start a Claude session, so that the thing I do most needs no prefix.
2. As a Launchy user, I want `#project`, `^host` and `@agent` to work at the start of what I type, in any order, so that `#leeandco ^air fix the deploy` starts that session on the Air.
3. As a Launchy user, I want the prompt line to show the Mac, project and agent my words resolved to, so that I can see where the session will start before I press ↩.
4. As a Launchy user, I want sessions that match what I'm typing listed below the prompt line, so that I notice when one already covers what I'm about to ask.
5. As a Launchy user, I want ↓ then ↩ to open a listed session, and ↩ alone always to start a new one, so that ↩ never surprises me.
6. As a Launchy user, I want my open sessions listed first, so that I go back to a running session rather than start a second one.
7. As a Launchy user, I want `#leeandco` alone to list that project's sessions, newest first, so that I can pick one up with ↓ ↩ or start fresh with ↩.
8. As a Launchy user, I want `^air` alone to list the Air's sessions, so that I can see what is on that Mac.
9. As a Launchy user, I want `?` to give me today's search, so that History, bookmarks and the relevance filter are one key away.
10. As a Launchy user, I want a message that ends in `?` to be a message, so that I can ask Claude a question.
11. As a Launchy user, I want what I type for Claude never sent to TypeSafe and never logged, so that a prompt stays on my Macs.
12. As a Launchy user, I want an empty panel to show my tabs and Recent as it does now, and ↩ to go back to the tab I left, so that ⌘N then ↩ still works.
13. As a Launchy user, I want a space and ↩ to start an interactive session in the default folder, so that I can still start one with no message.
14. As a Launchy user, I want `!` commands to work as they do now.

## Implementation Decisions

**One mode, read from the first character**
- The query has one mode, computed from it:
  - Empty: the session list.
  - Prompt: the default.
  - Search: a leading `?`.
  - Command: a leading `!`.
- Only the very first character counts. `?` or `!` after a space, or anywhere later, is part of the message.
- `panelHeight`, the view's branches, the arrows, ↩ and `runSearch` all switch over this one value, so no two of them can disagree about the mode. `isAskingClaude` and `claudePrefix` go. A search prefix, `?`, joins `commandPrefix` and `peerPrefix`.
- The message is the query with its leading spaces dropped, where today it is the text after `>`.

**Tokens**
- The leading words are the run of `^`, `#` and `@` words at the start of the message.
- A `^` word may come anywhere in that run, not only first. This is new, since today only the first word can name a Mac. `#` and `@` words then resolve against the named Mac's projects and agents, wherever the `^` word sits. That Mac's lists are asked for as they are today.
- A run with two `^` words is refused on the prompt line, the way a `^` word naming no Mac is refused today: "Name one Mac."
- Suggestions show while a leading word is being typed. They take the list's place, and ⇥ and ↩ complete them, as under `>`.
- Only resolved words act. A `#` or `@` word that names nothing stays in the message, as a file mention does today.
- The badges keep the order `^host #project @agent`, whatever order the words were typed in.

**The prompt line**
- It is today's ask row, and it shows the same things: the badges, the message (or "Start an interactive session" when there is none), an error in orange, or "Starting on …".
- Its Start hint shows only while it is highlighted.
- The highlight starts on it for every new query, and refinement passes never move it off. A query of only spaces is a prompt with no message. ↩ then starts an interactive session in the default folder, as `>` alone does today.
- ↩ on the prompt line, with or without ⌘, does what ↩ on the ask row does today:
  - It completes a suggestion whose word is still being typed.
  - It starts a session otherwise.
  - While a start on another Mac is pending, it does nothing.

**The session list under the prompt line** (decided by the user: sessions only, up to 5, filtered by the tokens)
- **Count.** Up to 5 sessions (a new constant). Search's own Sessions section keeps its 3.
- **Matching.** A session is matched on the message with the tokens removed, by keyword and by meaning. It is fused as search fuses sessions: the same similarity floor, with this Mac's open sessions first. Paired Macs' open sessions are marked open but not moved up, as in search today.
- **Filters.**
  - `#project` keeps sessions whose folder is the project or inside it.
  - `^host` keeps that Mac's sessions.
  - `@agent` keeps sessions run as that agent. The search rows have no agent field; it is in the session archive and in the paired Macs' session rows.
  - `^host` alone, with no project, still filters the list to that Mac (decided by the user). With no `^host` the list shows every Mac's sessions (decided by the user), as search does, though the session would start on this Mac.
- **Where the filter runs.** The filter is applied inside the store's queries, before the cut to 5, so a project with matching sessions always shows them.
- **No message** (decided by the user: ↩ on the prompt line starts an empty session there). With tokens and no message, the list is the filtered sessions: this Mac's open ones first, then by when they were last used. This needs a store query that lists session rows by folder, Mac and agent without a keyword. Without tokens or a message there is no list.
- **Layout.** A hairline, then a "Sessions" label (the session list's section label), then full-width rows of the session list's row height.
- **What a row shows.**
  - Claude's tile and the title.
  - A second line with the pills, then either the highlighted fragment for a keyword match, or the folder (when no `#project` pill names it) and "Last used …".
  - An "open" badge when the session is open here or on a paired Mac.
  - On the highlighted row, "Open ↩" for an open session and "Resume ↩" for the others.
- **Pills.** The pills, the agent's included, are worked out when the list is set, never while the row is drawn.
- **Keys and clicks.** ↓ on the prompt line moves to the first row, and ↑ on the first row moves back. ↩ or a click opens the session as a session result opens today. A click acts at once, as in the session list, because there is no preview pane to select for.
- **When matches arrive.** A row the user has moved to keeps the highlight by its id as matches arrive. If it drops out, the highlight goes to the first row, as in search today, and never back to the prompt line. Typing resets the highlight to the prompt line.
- **No match.** The prompt line shows alone.
- **Left out.** No preview pane, no footer, no pages and no relevance filter in this mode.

**What a prompt may reach**
- Prompt mode runs only the store's session queries and this Mac's embedder. It never runs a page query, and never the relevance filter, on TypeSafe or on this Mac.
- Nothing logs the query in prompt mode. Today's "no results" log lines print the query, so they stay in search mode. This follows the rule that a prompt is never logged.
- The message is cut to its first 1,000 characters before it is embedded. That is the cut the sessions' own embedding text has (verified). Today the embedder takes a query of any length (verified).

**Search (`?`)** (decided by the user: exactly today's search, its 3 sessions included)
- Search is today's search, run on the text after `?` and any spaces: Sessions (3) and Pages, the preview, the footer and the relevance filter. ↩ opens the top row and ⌘↩ copies a link.
- It keeps its session rows above the pages, so ↩ opens a session when one tops the list, as today.
- `?` alone shows one line in place of "No results": "Search history, bookmarks and sessions". It has the empty state's height.

**Empty field** (decided by the user: today's session list; a space and ↩ start an empty session)
- Today's session list, unchanged: the tabs, the paired Macs' open sessions and 5 Recent sessions, with today's highlight and ↩. There is no prompt line.

**The field**
- The placeholder becomes "Ask Claude Code…   ? search   ! commands". Check that it fits.
- The leading icon is Claude's sparkle, in Claude's colour, on an empty field and in prompt mode. Under `?` and `!` it is today's magnifier.

**Everything that read the `>` mode, and what it becomes**
- **The ask row** becomes the prompt line, shown in prompt mode, with the list or the suggestions under it.
- **Reloading the lists.** The project list's and the named Mac's lists reload in prompt mode, where they reloaded in the `>` mode.
- **The project scan** runs on the first character of a prompt, as it runs on `>` today.
- **The arrows and ↩** follow the new mode.
- **`panelHeight`** gets the prompt branch: the field, then the prompt line, then either the suggestions or the label and rows. It also gets the `?`-alone line. Every branch must add exactly what the view shows.
- **The start on another Mac** sends the same request. Its "open the pane at once" check becomes: the query is still the one that started it, and the board isn't showing. The mode test is implied, since that query was a prompt.
- **A session that dies at start** puts its line back in the field with its error. That line no longer has a `>`, so it lands in prompt mode with the error on the prompt line (verified).
- **`--search` and `--search-eval`** put `?` before each term themselves. They then measure what a `?` search does, and their callers, scripts outside the repository included, go on passing plain terms. Without this they would score prompt mode, which lists no pages, with no error.
- **Help text.** The placeholder changes. "No such command" under `!` is unchanged.
- **Settings.**
  - The Project folders detail becomes "start in with #name".
  - The Relevance filter's detail says it runs on a `?` search.
  - The Semantic search and TypeSafe texts stay true as they are.
- **Code comments** that say `>`, in the model and in the shared package's project type, change with them.
- **The glossary.**
  - **Prompt** becomes what is typed into the panel unless it starts with `?` or `!`.
  - **Command**'s avoid line drops "(that's `>`)".
  - The custom-apps skill reads the glossary through a link, so it follows. Its own instructions don't mention `>` (verified).
- **where-it-breaks.**
  - Panel size's list of branches becomes: prompt, with suggestions or sessions; search; `?` alone; command; empty field.
  - The search store's section gains that a prompt never reaches a reranker or a log.
- **Earlier problems' options** that mention `>` are records of past decisions and stay as they are.

**Unchanged**
- The `!` commands.
- The session board.
- The Phone page, which sends folder, agent and prompt as separate fields with no prefix.
- What is saved. No new setting or saved field, and `sessions.json` keeps its shape.

## Testing Decisions

- There is no test target. The mode of a query is a pure function and the first seam to test once there is one. These cases cover it:
  - `?x` is search.
  - ` ?x` and `x?` are prompts.
  - `!x` is a command.
  - An empty query is the session list.
  - `>x` is a prompt.
- The leading-word parse is the second seam to test. Check `#a ^b msg`, `^b #a msg`, two `^` words, and an unresolved `#word`.
- By hand, after the user restarts Launchy:
  - `fix the deploy` and ↩ starts a session in the default folder with that message.
  - `#launchy` and ↩ starts an empty session in the project. Before ↩, the list shows the project's sessions, open ones first.
  - `#leeandco ^air fix the deploy` shows the Air and leeandco badges, and ↩ starts on the Air in that folder. Swap the words and the result is the same.
  - Type words from an old session's prompt, ↓ and ↩: it resumes. Do the same with an open session's words: ↩ switches to its pane.
  - With matches arriving after the pause, the highlight stays on the prompt line, and ↩ starts a session.
  - `?github` gives today's results, preview and footer, and ↩ opens the top row. `?` alone shows the hint line.
  - `!kanban` shows the board.
  - On an empty field, ⌘N from a tab then ↩ goes back to that tab.
  - A space and ↩ starts an interactive session.
  - The panel has no clipped rows and no gap in each mode: prompt with 0 to 5 rows, prompt with suggestions, search, `?` alone, command, empty.
  - `Launchy --search` and `--search-eval` with a plain term give the same results as before the change.
  - With the relevance filter on, type a prompt and pause. No relevance check runs: no spinner, and nothing in the log.

## Out of Scope

- A new `!` command, or a change to the commands.
- Moving paired Macs' open sessions up beside this Mac's.
- Pages in the default mode (option 03; the user decided on sessions only).
- Showing the error of a resume that failed at start. Today it is set while the field is empty, so it shows nowhere (verified). This change doesn't touch it.
- The start on another Mac opening its pane over a tab the user switched to while it waited. Switching tabs doesn't clear the query, so the check passes (verified, existing). Worth a later look.
- Renaming the Back to search shortcut.

## Further Notes

- **Siblings.**
  - The prompt line is the ask row, and its suggestions are unchanged.
  - The session list's matching is search's Sessions section, with its fusion, floor and open-first rule.
  - Its rows follow the empty field's Recent and open-session rows.
  - The `?` mode is shaped like the `!` mode: a prefix read from the first character, with its own branch in the height and the view.
- **No ADR.** This changes how the panel reads its input, not how Launchy is built.
- **Search keeps its sessions,** as the user decided on 2026-10-07: `?` is exactly today's search.
- **Verified in the code** at d5ee26e:
  - Every reader of the `>` mode and every write to the query: the reset, `!kanban`, completing a suggestion, a session dying at start, `--search` and `--search-eval`. Nothing types `>` into the field.
  - Listening never writes to the field.
  - The `^` word is read only first.
  - The relevance filter's candidates are pages only, and it runs on any query of 3 characters or more.
  - The "no results" log lines print the query.
  - The embedder doesn't cut a query, and the session embedding text is cut at 1,000 characters.
  - The local reranker unloads after 10 idle minutes.
  - The project and Mac lists reload in the `>` mode.
  - A session dying at start puts its line back.
  - The Phone page sends no prefix.
  - The custom-apps skill's glossary is a link to the repo's.
  - No ADR or agent file mentions `>`.
- **Inferred, not checked:**
  - The user's Macs share folder paths, so a `#project` with no `^host` matches the same project's sessions on each Mac.
  - Embedding a capped message on each pause costs about what a search query does.
  - Scripts outside the repository call `--search` or `--search-eval` with plain terms. They weren't read.
