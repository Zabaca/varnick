---
title: A Claude session can't search for other sessions the way the user does in the panel
description: The user finds past Claude sessions by typing in the panel, where every session on this Mac and the paired Macs is ranked by its words and its meaning and shown under the tab that holds it. A session in a pane has no such search. Its Varnick tools can type into the panel's search field (`keys`), but `panel` reports only the field's mode and whether it is empty, never its text or its rows, so a session searches blind, and `keys` refuses ↩ on a row, so it can't open what it found either. Only the voice session has a search tool, and it is refused to every other pane.
impact: When the user asks a session to find, read or pick up an earlier session ("the one where we fixed the relay"), the session can only guess at folders and grep raw transcripts on this Mac with its own file tools, without the index, the meaning search, the paired Macs' sessions or the tabs' state that the panel uses. It can't hand back what it found or open it. The user goes back to the panel and does the search by hand, then tells the session what he found.
severity: mid
evidence: The user's words of 2026-10-20, relayed by the coordinator (below). Code read at main bddf4ce. The voice session's search tool is option 09 of `listening-never-answers`; Panel access is `sessions-cant-read-or-drive-varnick` and ADR 0031 with its amendments of 2026-10-17; session search is `sessions-not-searchable`, `session-search-sees-only-the-start`, `search-names-sessions-differently` and `launcher-defaults-to-search`.
status: open
---

## What the user asked (2026-10-20)

Asked whether a Claude session, through Varnick's MCP tools, can search and find Claude session transcripts, and told it can't:

> i want this as a new ability in the varnick mcp so you can search and find like i can from the launcher app

So: the same search the panel gives him, with its results handed back to the session, and the session able to act on what it finds.

## Today

Verified in the code at bddf4ce unless marked.

**What a session in a pane has**
- Every Claude pane on this Mac gets Panel access's tools and the pane tools, with no switch (ADR 0031's amendment of 2026-10-17): `panel`, `show`, `keys`, `board_read`, `pane_read`, `outline_read`, `outline_act`, `pane_open`, `pane_close`, and `notify`. Screen access's tools come only while its switch is on. A run of an automation, a Task step and a headless host's session get `notify` alone (and `task_result` for a step).
- **`panel`** gives the search's mode (the session list, a prompt, a `?` search, `!` commands) and whether the field is empty. Never its text, and never the rows. "Never: the search field's text" was the user's decision of 2026-10-11 for Panel access.
- **`keys`** can type into the search field while the panel is up and key and the user hasn't typed in it for 2 s. It refuses ↩ on a prompt (it would start a session), on a `?` result, and on a Recent row or a paired Mac's tab, so nothing it finds can be opened through it.
- **`show pane`** brings up a tab or pane that is open here, by an `s` id from `panel` or `board_read`. A card with no tab open here is refused ("no tab to show"). Nothing reopens a closed tab or resumes a past conversation.
- **`pane_open` with `kind: claude`** starts a new conversation with a first prompt. It takes no conversation to resume.
- **`board_read`** lists the board's cards (Running, Stopped, Completed), not past conversations.
- **A session's own file tools** can already read any transcript under Claude Code's projects folder on this Mac, raw (one JSON object per line, tool calls and their output included), as Claude Code's permission rules allow. That gives no ranking, no meaning, no paired Macs and no tab state.

**What the panel's search does** (what the user means by "like I can from the launcher")
- **Typing with no prefix** is a prompt. Under the prompt line the panel lists up to 5 sessions that match what is typed, keyword and meaning fused, with a similarity floor for sessions matched by meaning alone, this Mac's open ones first. Leading `#project`, `^mac` and `@agent` words keep only those sessions.
- **`?` search** lists up to 3 sessions above the pages (History and bookmarks), ranked the same way. Sessions never go to the relevance filter.
- **Each session match shows under the tab that holds it,** with the tab's standing: Open, Closed or Done, and "on <Mac>" for a paired Mac's. The tab is found from the open tabs, Recent, Stopped and Completed, the paired Macs' listings, else the search database's own record of it.
- **A row** shows the session's name (⌘⇧R name, else its /rename name, else Claude's title, else the first prompt's first line), and as its second line the matching fragment of a prompt when a keyword matched, else its folder and when it was last used.
- **↩ on a row** brings up its tab if it is open here; opens a paired Mac's open tab on cards; reopens a closed tab from Completed, Recent or the ended cards; else resumes the conversation in a new tab in its own folder, as its agent, on the Mac that holds it.
- **With the field empty** the panel lists the open tabs, then Recent (closed tabs).

**What session search holds**
- Every Claude Code transcript under this account's projects folder with at least one prompt the user typed, wherever it was started (a Varnick pane or a plain terminal), and the paired Macs' sessions as they send them: title, folder, agent, every typed prompt, the last text Claude wrote after each (cut at 1,000 characters) and first and last prompt times.
- Keyword search covers the title, prompts and tags (folder and agent). Search by meaning embeds each exchange (a prompt and Claude's last reply after it) and scores a session by its best one (ADR 0018).
- **Which exchange scored best is not kept.** The store maps every exchange vector to its session's row and keeps the best score only, so nothing today can say which part of a long session matched by meaning.
- Sessions run by tools (no typed prompt), subagent transcripts and sessions whose folder is gone are left out. The voice session's and automation runs' conversations are indexed like any (the voice session's per option 09 of `listening-never-answers`; runs inferred from the reader's rule, since a run's prompt is passed as a typed one).
- With no words and no filter, the store can list every session, most recently used first.

**The one search tool there is: the voice session's `search`**
- Listed only for the voice session, refused from any other pane ("Only Varnick's voice session may use this tool"), and off while Answer with Varnick's own steps is on. Listing it in every pane was question (g) of option 09, answered "not in this option".
- It runs the spoken pipeline's search step with no filter and no judge: up to 20 pages and 3 sessions, each with its kind, title, site or folder, when in words, and a description or the session's prompts from the start, cut at 300 characters. A page has its address; a session has its conversation id and, on this Mac, its transcript's path for Read, else the paired Mac's name. It drops the calling session's own conversation, and takes `project`, `from` and `to`.
- No tab, no standing, no matching fragment, and nothing to open with.

**Privacy on record**
- Panel access's reads go to Anthropic with the session that reads them. ADR 0031 lists what a session may be shown and says "not a transcript or a prompt that neither the card nor the screen shows". Each tool that reads more says so in `docs/privacy-and-security.md` and the README before it ships.
- Session search's text stays on this Mac, on the paired Macs and on the user's embeddings server when he set one. It never goes to TypeSafe. The voice session's search tool is the one path by which its rows reach Anthropic, and the privacy doc says so.
- Varnick's log for these tools holds the tool, the outcome's kind, counts and durations, never a word of a query or a row.

## Settled after the options were written (2026-10-20)

- **A headless host's sessions are not in session search:** a headless host answers a paired Mac's `rows` request with no rows (verified at bddf4ce).
- **How large a session's text is once tool output is left out:** measured on this Mac, aggregates in option 01's Further Notes. The median session is about 8,300 characters, and about one in five is over 40,000, so a read has to be paged.

## Left to decide

- **What a session can search:** sessions only, or History and bookmarks too; this Mac's and the paired Macs'; filters by project, Mac, agent and time.
- **What a result returns:** name, project, Mac, when, the tab and its standing, a matching excerpt, and an id the other tools take.
- **What it can do with a result:** read more of the conversation, show it to the user in the panel, reopen or resume it.
- **The privacy line:** what goes to Anthropic with the calling session, and what stays out.
