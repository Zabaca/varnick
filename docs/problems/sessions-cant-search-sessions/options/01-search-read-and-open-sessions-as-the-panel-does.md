---
problem: sessions-cant-search-sessions
title: Three session tools in every pane, that search sessions as the panel's prompt line does, read one, and open it as ↩ does
summary: Recommended. Every Claude pane that has Panel access gets three tools. `sessions_search` ranks sessions exactly as the panel's prompt line does (words and meaning, the same floor, this Mac's open ones first), on this Mac and the paired Macs, narrowed by project, Mac, agent and time, and answers up to 5 by default (20 at most), each with its name, project, Mac, when it was last used, its tab and whether that is Open, Closed or Done, a matching excerpt, its conversation id and an `s` id when a pane here is on it. `session_read` gives one session's conversation as text, the user's prompts and what Claude wrote, never tool calls, tool output or thinking, paged by exchange and able to start at the one that matched. `session_open` does what ↩ on the row does: brings its tab up, reopens a closed tab, or resumes the conversation in a new tab on the Mac that holds it, or, with `place: beside`, resumes it beside the calling pane. Sessions only: no History or bookmarks. Search and read send what they return to Anthropic with the calling session; nothing goes to TypeSafe and nothing is logged but kinds and counts.
status: proposed
---

## Solution

Three new tools join Panel access's set, so every Claude pane that lists `panel` lists them, from its next start or restart. No switch, as Panel access has none. Each call is a Panel access request on the user-only socket, answered on the main actor by the running Varnick, after the router's own checks (Varnick started, the calling pane is a Claude pane here).

| Tool | Arguments | What it does |
|---|---|---|
| `sessions_search` | `query`, `project`, `mac`, `agent`, `from`, `to`, `limit` | The sessions the panel's prompt line would list for those words with those `#project`, `^mac` and `@agent` words, in the same order, with the tab each is in. |
| `session_read` | `conversation`, `around`, `after`, `last` | One session's conversation as text: each exchange's prompt and Claude's written text, numbered, paged. |
| `session_open` | `conversation`, `place` | What ↩ on that session's row does, or the conversation resumed beside this pane. |

**Searching** runs the passes the panel runs for its prompt line: keyword matches and the words' meaning fused by reciprocal rank, the meaning-only similarity floor, and the conversations a pane here is on first. A project, Mac, agent or time range keeps only those sessions before the cut, as the leading words do in the panel; with a project or a time and no words, the most recently used come first. With no words and no filter it lists the most recently used sessions, which is the nearest a session gets to the panel's empty-field list. The calling session's own conversation is left out, as the voice session's tool leaves it out.

**Each result** says, in this order:
- its name, as the board and the panel name it;
- its project folder's name and its full folder on this Mac, or the paired Mac's name and the folder there;
- its agent, when it was started as one;
- when it was first and last used (a date and time, and in words for the past week);
- its tab: the tab's name, and Open, Closed or Done, "on <Mac>" for a paired Mac's, or "no tab" when none is known;
- whether a pane here is on it now, with that pane's `s` id (the one `show`, `pane_read` and `board_read` use) and its turn;
- how it matched (words, meaning or both) and a **matching excerpt**: for a keyword match, the fragment of the prompt the words are in, with the words marked; for a match by meaning, the start of the exchange that scored best; and the number of that exchange, which `session_read` takes;
- its conversation id, which the other two tools take.

**Reading** gives a session's exchanges in order. Each is its number, when its prompt was typed, the prompt, and every text block Claude wrote before the next prompt. Tool calls, tool results, thinking, sidechains and Claude Code's own synthetic entries are left out, so command output and file contents a session read are not in it. `around` starts at an exchange (the excerpt's number) with a few before it; `after` continues where a capped read stopped; `last` gives the most recent exchanges. Each call stops at a size cap and ends with the exact call that continues it, as `outline_read` does. A paired Mac's session gives what that Mac already sends: every prompt, and Claude's last reply after each cut at 1,000 characters, marked as such.

**Opening** with `place` left out does exactly what ↩ on the session's row in the panel does, through the same function: it brings the tab up if it is open here, opens a paired Mac's open tab on cards, reopens a closed tab from Completed, Recent or the ended cards with every pane it had, or resumes the conversation alone in a new tab, in its own folder, as its agent, on the Mac that holds it. It follows `show`'s rules: it never brings the panel up, hides or pins it, takes no keyboard and clears nothing the user typed, and it is refused while the panel is hidden, while Settings, the Restart Varnick card or the split picker shows, and for 2 s after the user's key. With `place: beside` (or `below`) it resumes the conversation in a new pane beside the calling session's, as `pane_open` places a pane, and that works with the panel hidden.

## Trade-offs

- **The same search the user has,** by the same code: a session finds what the panel would show for the same words, the paired Macs' sessions included, and sees where each one lives now. A fix to ranking is a fix to both.
- **More than the panel shows, by asking.** The panel shows 5 under the prompt line; a session can ask for up to 20. Past the panel's few, the floor still keeps unrelated sessions out, so a broad search may answer fewer than it asked for.
- **A matching excerpt for a match by meaning needs a change to the search store.** Today the store keeps each session's best score and not which exchange gave it. It has to keep the exchange's position beside each vector. The panel could show the same excerpt later; this option doesn't change the panel.
- **Reading is clean, but not complete.** Leaving tool output out keeps a read small and keeps file contents and command output (secrets that were printed included) out of it. A session that needs what a tool returned can still read the raw transcript on this Mac with its own file tools, as it can today.
- **A paired Mac's sessions read thin.** Their prompts are whole, but each exchange has only Claude's last reply, cut at 1,000 characters. Reading them whole would need a new request between Macs and a protocol change (Out of Scope, and a question below).
- **Opening starts sessions.** Reopening a closed tab or resuming a conversation starts Claude in a pane, on the user's plan, with nobody asked, as `pane_open` already can. A reopened tab shows in the panel's strip and, while the panel is up, comes to the front, as the user's ↩ would.
- **More reaches Anthropic.** What a search or a read returns goes to Anthropic with the calling session and stays in its transcript: other sessions' names, folders, Macs, tab names, excerpts of the user's prompts and of Claude's replies, and with `session_read` whole prompts and Claude's whole text. That is what ADR 0031 kept out ("not a transcript or a prompt that neither the card nor the screen shows"), so it is a privacy change, written down before it ships. Browsing history and bookmarks stay out.
- **Every pane gets it,** with nothing to turn it off, as with the rest of Panel access. Claude Code's per-tool rules can still ask before `session_open` (inferred, as for `outline_act`).

## User Stories

1. As the user, I want to ask a session to find an earlier session in my own words and get back what the panel would show me, so that I don't have to search by hand and tell it what I found.
2. As the user, I want a session's search to cover my paired Macs' sessions too, so that where a session ran doesn't change whether it is found.
3. As the user, I want to narrow a session's search by project, Mac, agent or time, as my `#`, `^` and `@` words do, so that "last week in the relay project" finds what I mean.
4. As the user, I want each result to say its tab and whether that tab is open, closed or done, so that the session knows whether it is live work or history.
5. As the user, I want each result to show the part of the session that matched, so that the session can tell look-alike sessions apart without reading each one.
6. As the user, I want a session to read what was said in another session, prompts and Claude's answers, without the tool output, so that it can pick up where that one left off.
7. As the user, I want a session to bring a found session up in my panel the way ↩ would, so that I can see it.
8. As the user, I want a session to resume a past conversation beside itself, so that it can ask that session something while I keep working.
9. As the user, I want none of this to bring my panel up over the app I'm in, or take my typing, so that a session searching never gets in my way.
10. As the user, I want my browsing history kept out of this, so that a session searching for sessions doesn't send my history to Anthropic.
11. As the user, I want Varnick's log to keep none of the words searched or read, so that the log stays as private as it is now.

## Implementation Decisions

**Where the tools live**
- In Panel access's set, listed after `panel`, `show` and `keys`, so every pane that has Panel access has them (ADR 0031's amendment of 2026-10-17 is the one statement of which sessions get which sets; it gains these names). The voice session has Panel access's set, so it gets them too and keeps its own `search`. Runs, Task steps and headless hosts get none, as they get no Panel access.
- They are router tools like `panel` and `show`, not a `PanelAccessView`: they read no view. The router answers them through one new type beside `VoiceSearchAccess`, which runs the search passes the panel's prompt line runs. The panel's `listPromptSessions` and the new tool share one ranking function, so the two can't drift; the voice session's tool is left as it is.
- **The request is unchanged:** Panel access's request with new tool names. `PanelRequest.version` stays, the relay still refuses a line without `op`, and no peer protocol change is needed.
- **A tab another machine controls:** `sessions_search` and `session_read` only describe, so they join the tools answered there (`answersControlled`), at the user's word of 2026-10-17 for reads. `session_open` keeps the refusal, as `show` does.

**`sessions_search`**
- `query`: words, at most the panel's prompt-line limit (1,000 characters); optional.
- `project`: a folder's name (any folder of that name, on any Mac) or a full path (that folder and everything under it), as the panel's `#project` and the spoken pipeline's folder names do.
- `mac`: a paired Mac's name as the peer list names it, or "this Mac". `agent`: an agent's name.
- `from`, `to`: ISO 8601 dates or times; a session counts when it was used at any time in the range (first prompt before the end, last after the start), the store's existing time filter.
- `limit`: 5 by default, 1 to 20.
- **Ranking:** the prompt line's: keyword and meaning, fused; the meaning-only floor (`sessionSimilarityFloor`), dropped when a project or a time chose the sessions, as the spoken pipeline drops it; this Mac's open conversations first. No relevance filter and no judge, as sessions never have one.
- **Leaving out:** the calling session's own conversation, before the cut (ask for one more).
- **Tabs:** each session's tab and standing come from the same function that groups the panel's rows under their tabs. A tab's row itself is not a result; each result carries its tab.
- **The excerpt:** the store's keyword snippet with its highlight marks turned into plain markers; for a match by meaning, the best exchange's text, cut at 300 characters. The store keeps each exchange vector's position beside its row id when it loads them, and the semantic ranking returns the best position with the best score. A match by both gives the keyword snippet and the exchange's number.
- **No embedder** (no model and no server): keyword only, and the reply says so on its first line.
- **The reply:** a first line ("5 sessions, best first" or "No session matched"), then one block per result in the order above. Times as dates with the time of day, plus the spoken pipeline's words for the past week. Conversation ids in full. An `s` id only for a pane on this Mac, from the calling pane's own table.

**`session_read`**
- `conversation`: an id, as `sessions_search` gives it. Any session in the index may be read, not only one a search returned. The calling session's own conversation is refused (it has its own context).
- **This Mac's session:** read from its transcript, the newest copy when a session left one in two folders (the rule the index uses). An exchange starts at a typed prompt, as the index defines one; its text is the prompt, then every text block Claude wrote until the next typed prompt, in order. A task notification, a teammate's message or an interruption is shown as a one-line marker, not as a prompt.
- **A paired Mac's session:** the prompts and last replies that Mac sent, numbered the same way, with a first line saying only Claude's last reply after each prompt is kept, cut at 1,000 characters.
- `around`: an exchange number; the read starts two exchanges before it. `after`: continue from the exchange after that number. `last`: the most recent N exchanges. With none, it starts at the first exchange.
- **Bounded, and continued:** about 40,000 characters a call, a single prompt or reply cut at 8,000 with a marker (both numbers are guesses for the builder to check against real sessions), and a last line naming the exact call that continues it.
- **Live sessions:** a session that is working now is read as its transcript stands, and the reply says it is still running.

**`session_open`**
- `conversation`: an id. Refused for the calling session's own conversation, and for one this Mac can't find in the index.
- **No `place`:** the function ↩ runs on that session's row (`openMatch`), so the same tab rules apply: open here comes up with that pane focused; open on a paired Mac opens its tab on cards; closed reopens whole from Completed, Recent or the ended cards; with no tab left it resumes alone in a new tab, on the Mac that holds it, in its own folder, as its agent. `show`'s refusals apply first (panel hidden, Settings, the Restart Varnick card, the split picker, the tab strip's list, a key within 2 s), since it changes what the panel shows.
- **`place: beside` or `below`:** a new Claude pane in the calling pane's tab, resuming the conversation, placed as `pane_open` places a pane and with its rules: focus stays where it was, the panel is never raised, a new pane never skips permission checks when the caller doesn't, and the pane counts as opened by this session for `pane_close`. A conversation already open in a pane here is refused with that pane's `s` id ("open in s4: use show"), so it is never resumed twice on this Mac. A paired Mac's conversation is refused with `place` (it resumes on that Mac, which needs the tab form).
- **The reply:** what happened ("Brought up its tab", "Reopened the closed tab", "Resumed in a new tab", "Resumed beside this pane as s7"), the `s` id of the pane now on it, and whether the panel was hidden.
- **Not:** ending, marking or restarting a session, or typing into one.

**Refusals,** each a sentence the session can act on: Varnick is still starting; the calling pane is not a Claude pane here; an unknown conversation; the caller's own conversation; a bad argument (a date that doesn't parse, an unknown Mac or agent, a `limit` out of range); `session_open`'s view and pane refusals above.

**The log:** one line per call, as the router writes it: the tool, the outcome's kind, counts (results, exchanges, characters) and the duration. Never a query word, a project, a name, an excerpt or a conversation id.

**Docs the builder updates with the code**
- ADR 0031: an amendment, "Sessions search, read and open other sessions", reversing for these tools "not a transcript or a prompt that neither the card nor the screen shows", and adding the names to the amendment that says which sessions get which sets.
- ADR 0018 or a line in where-it-breaks: the store keeps each exchange vector's position, and the semantic ranking still keeps one entry per session before fusion.
- `docs/privacy-and-security.md`, under Panel access: what a search and a read send to Anthropic (the list in the Trade-offs), that History and bookmarks are not searched by these tools, that nothing goes to TypeSafe, and that `session_open` can start sessions on the user's plan.
- `CONTEXT.md`: **Session** gains that a session can search, read and open sessions through Panel access.
- `docs/agents/where-it-breaks.md`, Panel access: these tools, their limits, the shared ranking function, and that the voice session keeps its own `search`.
- README and the guide: one line each.

**State:** none saved. No new defaults key, no `sessions.json` change, no change to the search database's tables. The exchange positions live in the store's memory.

**Where it breaks.** The items of `docs/agents/where-it-breaks.md` this touches:
- **Search store:** sessions never go to the relevance filter; several vectors map to one session row and the ranking keeps one per session before fusion; the meaning-only floor.
- **Panel access:** `--mcp` never reads or acts; the router's order; the tools answered in a controlled tab; `show`'s refusals and "never the panel's visibility"; the pane tools' permission rule and "opened by this session".
- **Focus and keys:** a view changes only through the model's own functions; a tab under a hidden panel is not swapped.
- **Peers:** nothing new is asked of a paired Mac; a paired Mac's open tab opens on cards; a conversation resumes on the Mac that holds it.

## Testing Decisions

- **No test target.** `make build`, `make check-mcp`, then by hand after the user restarts Varnick and restarts a session.
- **Seams for a test target later,** all pure: the arguments into words and a session filter; a transcript's lines into exchanges for a read (prompts, Claude's text, markers, the cut and the continuation); the best exchange's position from the ranking.
- **`make check-mcp`:** the three tools are listed wherever `panel` is, and not for a run, a Task step or a headless host.
- **By hand, in a restarted session:**
  - `sessions_search` with words the user would type gives the same sessions, in the same order, as the panel's prompt line for the same words; with `project`, the same as `#project`; with `mac`, the same as `^mac`.
  - A session matched by meaning only has an excerpt from the exchange that matched; `session_read` with `around` that number starts there.
  - An unrelated search (a recipe, a news site) answers no sessions.
  - A paired Mac's session shows its Mac and tab standing; reading it says it holds last replies only.
  - Each tab standing: a session open here (with its `s` id), one in Recent, one in Completed, one with no tab.
  - `session_read` of a long session pages to the end with the calls it names; no tool output appears.
  - `session_open` on an open session brings its tab up; on a closed tab reopens it whole; on a session with no tab resumes it in a new tab in its folder as its agent; with the panel hidden it is refused; with `place: beside` it opens beside the caller and `pane_close` can close it.
  - Varnick's log holds kinds and counts only.

## Out of Scope

- History and bookmarks (option 02 reaches them; a question below).
- A paired Mac's full transcript, which needs a new request between Macs and a protocol change.
- Showing a session in the panel without opening it (option 03 shows the panel's own search instead).
- Ending, marking, restarting or typing into a found session; typing into sessions belongs to `orchestration-lives-in-one-session`.
- Changing what the panel shows for a match by meaning (the new excerpt could be shown there later).
- Sessions a headless host keeps, beyond whatever session search already holds of them (unverified).
- The voice session's `search`, which stays as it is.

## Further Notes

**Decisions for the user, each with the planner's recommendation**
- **(a) Sessions only, or your browsing history and bookmarks too?** Sessions only. Your ask was to find sessions, and history and bookmarks going to every session is a bigger privacy step than the ask needs. The voice session keeps its own tool that searches all three.
- **(b) May a session read other sessions' prompts and Claude's answers in full, sending them to Anthropic?** Yes, without tool output. A session can already read the raw transcripts on this Mac with its own file tools; this makes it easy, and keeps command output and file contents out.
- **(c) Your paired Macs' sessions:** found and opened, yes. Read whole? Not now: a read gives the prompts and Claude's last reply after each, which those Macs already send. Reading them whole means a new request between your Macs.
- **(d) May a session reopen or resume a session without asking you?** Yes, as ↩ does and as `pane_open` already starts sessions. It never brings the panel up over the app you're in, and is refused while the panel is hidden unless it resumes the session beside itself.
- **(e) Where a resumed session appears:** in its own tab, as ↩ puts it (the default), with "beside this session" as the other place.
- **(f) Hidden runs and the voice session's conversations** are found like any session, as in the panel. Yes, so a session finds what you would.
- **(g) No setting to turn it off,** as with the rest of Panel access. Yes, matching your 2026-10-17 word.

**Rough effort:** one slice for search and read, a second for open and the excerpt by meaning; about 700 to 1,000 lines with the docs.

**Verified in the code at bddf4ce**
- Which sets each pane gets, and that the voice session's `search` is listed for it alone and refused from other panes.
- `panel` gives the search's mode and emptiness only; `keys` refuses ↩ on a prompt, a `?` result and a Recent or paired Mac's row; `show pane` refuses a card with no tab open here; `pane_open` takes no conversation to resume.
- The prompt line's ranking (keyword and meaning fused, the floor, open here first, the `#`, `^` and `@` filter applied before the cut, 5 shown), the `?` search's 3 sessions, and the store's time and folder-name filters.
- The grouping under tabs and the Open, Closed and Done standing; ↩'s path through `openMatch`, `openTab` and `resumeSession`.
- A row's second line: the keyword fragment, else the folder and when.
- The store keeps one best score per session and no exchange position.
- The router's order, the tools answered in a controlled tab, and its log line.

**Inferred**
- Automation runs' conversations are indexed, since a run's prompt is passed as a typed one.
- Claude Code's per-tool rules can ask before `session_open` while allowing the reads.
- 40,000 and 8,000 characters as a read's caps.

**Unverified, for the builder to check first**
- How much of a long session's text is Claude's writing once tool output is out, which sets the read's cap.
- That a reopened tab under a visible panel that is not key leaves every terminal's size alone (the rule `show` already follows).
